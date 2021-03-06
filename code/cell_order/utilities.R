
library(parallel)

## Bayesian cell re-ordering mechanism

## One iteration of cell reordering that takes the data as input and some
## current iterate of cell times and obtains new set of parameters of amplitude,
## phase and noise variation, and also refined estimates of cell times

atan3 <- function(beta2, beta1)
{
  if (beta1 > 0)
    v <- atan(beta2/beta1);
  if(beta2 >=0 & beta1 <0)
    v <- pi + atan(beta2/beta1);
  if(beta2 <0 & beta1 <0)
    v <- -pi + atan(beta2/beta1);
  if(beta2 >0 & beta1==0)
    v <- pi/2;
  if(beta2 <0 & beta1==0)
    v <- - (pi/2);
  if (v < 0)
    v <- v + 2*pi;
   # print(v)
   #  print(beta1)
   #  print(beta2)
  return(v)
}

cell_reordering_iter <- function(cycle_data, celltime_levels, cell_times_iter, fix.phase=FALSE, phase_in=NULL)
{
  if(fix.phase==TRUE & is.null(phase_in))
    stop("fix.phase=TRUE and phase not provided")
  if(fix.phase==FALSE & !is.null(phase_in))
    stop("fix.phase=FALSE and phase provided")
  if(length(unique(cell_times_iter))==1)
    stop("All the points have converged at same point on cycle");
  
  # cycle_data: a N \times G matrix, where N is number of cells, G number of genes
  # cell_times_iter:  the vector of cell times taken as input (a N \times 1)
  G <- dim(cycle_data)[2];
  numcells <- dim(cycle_data)[1];
  sigma <- array(0,G);
  amp <- array(0,G); phi <- array(0,G);
  
  if(!fix.phase){
  for(g in 1:G)
  {
    fit <- lm(cycle_data[,g]  ~ sin(cell_times_iter) + cos(cell_times_iter) -1);
    sigma[g] <- sd(fit$residuals);
    beta1 <- fit$coefficients[1];
    beta2 <- fit$coefficients[2];
    if(beta1==0 & beta2==0){
      stop(paste0("You have a gene with all 0 counts at gene",g));
    }
    amp[g] <- sqrt(beta1^2 + beta2^2);
    phi[g] <- atan3(as.numeric(beta2), as.numeric(beta1));
  }
  }
  
  if(fix.phase){
    phi <- phase_in;
    for(g in 1:G)
    {
      fit <- lm(cycle_data[,g]  ~ sin(cell_times_iter+phi[g]) -1);
      sigma[g] <- sd(fit$residuals);
      amp[g] <- abs(fit$coefficients[1]);
    }
  }
  
  
  cell_times_class <- seq(0, 2*pi, 2*pi/(celltime_levels-1));
  num_celltime_class <- length(cell_times_class);
  
  sin_class_times <- sin(cell_times_class);
  cos_class_times <- cos(cell_times_class);
  sin_phi_genes <- sin(phi);
  cos_phi_genes <- cos(phi);
  sinu_signal <- cbind(sin_class_times, cos_class_times) %*% rbind(amp*cos_phi_genes, amp*sin_phi_genes);
  options(digits=12)
  signal_intensity_per_class <- matrix(0, numcells, num_celltime_class)
  
  signal_intensity_per_class <- do.call(rbind,mclapply(1:numcells, function(cell) 
                        {
                           res_error <- sweep(sinu_signal,2,cycle_data[cell,]);
                           res_error_adjusted <- -(res_error^2);
                           res_error_adjusted <- sweep(res_error_adjusted, 2, 2*sigma^2, '/');
                           out <- rowSums(sweep(res_error_adjusted,2,log(sigma)) - 0.5*log(2*pi));
                           return(out)
                        }, mc.cores=detectCores()));
  
#  signal_intensity_per_class_2 <- matrix(0, numcells, num_celltime_class)
  
#  signal_intensity_per_class_2 <- do.call(rbind,mclapply(1:numcells, function(cell) 
#  {
#    out <- array(0,length(cell_times_class));
#    for(times in 1:length(cell_times_class))
#    {
#      out[times] <- sum(mapply(dnorm, cycle_data[cell,], amp * sin(cell_times_class[times] + phi), sigma,log=TRUE));
#    }
#    return(out)
#  }, mc.cores=detectCores()));
  
  
  
  signal_intensity_class_exp <- do.call(rbind,lapply(1:dim(signal_intensity_per_class)[1], function(x) 
                                                                        {
                                                                            out <- exp(signal_intensity_per_class[x,]- max(signal_intensity_per_class[x,]));
                                                                            return(out)
                                                                        }));
  
  cell_times <- cell_times_class[unlist(lapply(1:dim(signal_intensity_class_exp)[1], function(x) 
                                                                                {
                                                                                  temp <- signal_intensity_class_exp[x,];
                                                                                  if(length(unique(signal_intensity_class_exp[x,]))==1)
                                                                                    out <- sample(1:dim(signal_intensity_class_exp)[2],1)
                                                                                  else
                                                                                    out <- which(rmultinom(1,1,signal_intensity_class_exp[x,])==1);
                                                                                  return(out)
                                                                                }))];

  out <- list("cell_times_iter"=cell_times, "amp_iter"=amp, "phi_iter"=phi, "sigma_iter"=sigma, "signal_intensity"=signal_intensity_per_class);
  return(out)
}

## calculate log likelihood under estimated cell times and amplitude
## phase and variation parameters 


loglik_cell_cycle <- function(cycle_data, cell_times, amp, phi, sigma)
{
  # cycle_data: a N \times G matrix, where N is number of cells, G number of genes
  # cell_times : a N \times 1 vector of cell times 
  # amp: the amplitude vector (G \times 1) over the genes 
  # phi: the G \times 1 vector of phase values over genes
  # sigma: the G \times 1 vector of gene variation
  
  G <- dim(cycle_data)[2];
  numcells <- dim(cycle_data)[1];
  sum <- 0;
  
  for(s in 1:numcells)
  {
    sum <- sum + sum(mapply(dnorm, cycle_data[s,],amp * sin(cell_times[s] + phi), sigma, log=TRUE));
  }
  
  return(sum)
}

## main workhorse function that takes in data and number of discrete levels 
## of cell times along with the number of iterations

cell_reordering_phase <- function(cycle_data, celltime_levels, num_iter, save_path=NULL,
                                  fix.phase=FALSE, phase_in=NULL)
{
  # cycle_data: a N \times G matrix, where N is number of cells, G number of genes
  # celltime_levels: number of discrete cell times used for estimation
  
  # We assume all the G genes are sinusoidal, if some are not, filter them
  
  G <- dim(cycle_data)[2];
  numcells <- dim(cycle_data)[1];
  
  celltimes_choice <- seq(0, 2*pi, 2*pi/(celltime_levels-1));
  cell_times_init <- sample(celltimes_choice, numcells, replace=TRUE);
  
  cell_times_iter <- cell_times_init;
  
  for(iter in 1:num_iter)
  {
    fun <- cell_reordering_iter(cycle_data, celltime_levels, cell_times_iter, fix.phase, phase_in);
    cell_times_iter <- fun$cell_times_iter;
    amp_iter <- fun$amp_iter;
    phi_iter <- fun$phi_iter;
    sigma_iter <- fun$sigma_iter;
    loglik_iter <- loglik_cell_cycle(cycle_data, cell_times_iter, amp_iter, phi_iter, sigma_iter);
    cat("The loglikelihood after iter", iter, "is:", loglik_iter,"\n")
  }
  
  out <- list("cell_times"=cell_times_iter, "amp"=amp_iter,"phi"=phi_iter, "sigma"=sigma_iter, "loglik"=loglik_iter)
  
  if(!is.null(save_path)){
   save(out,file=save_path);
  }
  
  return(out)
}

cell_reordering_full <- function(cycle_data, celltime_levels, cell_times, amp, phi, sigma)
{
  numcells <- dim(cycle_data)[1];
  G <- dim(cycle_data)[2];
  cell_times_class <- seq(0, 2*pi, 2*pi/(celltime_levels-1));
  sorted_cell_times_class <- sort(cell_times_class)
  order_class <- order(cell_times_class);
  
  signal_intensity <- do.call(rbind,mclapply(1:numcells, function(cell) 
  {
    out <- array(0,length(cell_times_class));
    for(times in 1:length(cell_times_class))
    {
      out[times] <- sum(mapply(dnorm, cycle_data[cell,], amp * sin(cell_times_class[times] + phi), sigma,log=TRUE));
    }
    return(out)
  }, mc.cores=detectCores()));
  
  
  
  signal_intensity <- signal_intensity[,order_class];
  
  cell_order_full <- array(0,numcells)
  
  for(cell in 1:numcells)
  {
    max_index <- which.max(signal_intensity[cell,]);
    if(max_index==1){
      denominator <- signal_intensity[cell,max_index] - signal_intensity[cell,(max_index+1)];
      numerator <- signal_intensity[cell,max_index] - signal_intensity[cell,celltime_levels];
      ratio <- numerator/(numerator+denominator);
      cell_order_full[cell] <- sorted_cell_times_class[celltime_levels] + ratio*4*pi/(celltime_levels-1);
    }else if(max_index==celltime_levels){
      denominator <- signal_intensity[cell,max_index] - signal_intensity[cell,1];
      numerator <- signal_intensity[cell,max_index] - signal_intensity[cell,(max_index-1)];
      ratio <- numerator/(numerator+denominator);
      cell_order_full[cell] <- sorted_cell_times_class[(max_index-1)] + ratio*4*pi/(celltime_levels-1);
    } else {
      denominator <- signal_intensity[cell,max_index] - signal_intensity[cell,(max_index+1)];
      numerator <- signal_intensity[cell,max_index] - signal_intensity[cell,(max_index-1)];
      ratio <- numerator/(numerator+denominator);
      cell_order_full[cell] <- sorted_cell_times_class[(max_index-1)] + ratio*4*pi/(celltime_levels-1);
    }
  }
  
  return(cell_order_full)
}

