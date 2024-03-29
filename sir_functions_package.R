library(tidyverse)

# Hidden functions

## sorter

### inputs: 
# X: dataframe or matrix
# Y: dataframe or matrix with one column

### output: 
# dataframe with rows sorted by their Y values

sorter <- function(X, Y) {
    # turn X and Y into data.frames
  X <- X %>% as.data.frame()
  Y <- Y %>% as.data.frame()
    # combine X and Y
  data <- cbind(X, Y)
    # give newly created Y column a name
  colnames(data)[ncol(data)] <- "y_vals"
    # sort by Y
  data <- data %>% arrange(y_vals)
    # remove column of Y values
  data <- data[,-ncol(data)]
    # return sorted dataframe
  return(data)
}

## allocator

### inputs: 
# nrows: number of rows in the X dataframe/matrix
# slices: integer that is number of slices for our SIR algorithm

### output: vector of slice allocations of length n (e.g (1,1,2,2) )

allocator <- function(nrows, slices = 8) {
  rem <- nrows%%slices
  sizes <- rep(0, slices)
  for (i in 1:slices) {
    if (i <= rem) {
      sizes[i] <- nrows%/%slices + 1
    } else {
      sizes[i] <- nrows%/%slices
    }
  }
  allocation <- c()
  for (i in 1:slices) {
    allocation <- allocation %>% append(rep(i, sizes[i]))
  }
  return(allocation)
}

## slicer

### inputs:
# X: dataframe or matrix
# Y: dataframe with one column
# slices: integer with number of slices. (Only) necessary if response is continuous.
# categorical: binary, states if the response is categorical or not. Default is FALSE ( = continuous response)

### output: dataframe of size slices * p, containing the means for each slice for each column.

slicer <- function(X, Y, slices = 8, categorical = FALSE) { # this is a slicer for univariate Y: if Y is multivariate, need to make it univariate in a previous step
  # Ensure X is a data.frane 
  X <- X %>% as.data.frame()
  if (!categorical) { # if Y continuous, create new 'slice' column in X in the appropriate way
    data <- sorter(X, Y)
    nX <- nrow(X)
    data$slice <- allocator(nrows = nX, slices = slices)
  } else { # if Y categorical: add new 'slice' column that is Y values (and sort by those values)
    data <- X %>% as.data.frame()
    data$slice <- Y[,1]
    data <- data %>% arrange(slice)
    slices <- length(unique(data$slice))
  }
  slice_names <- unique(data$slice) # need this change so that it works when we have slice names as tile coords
  
  long_values_sliced_dataframe <- c()
  
  for (s in 1:slices) { 
    for (i in 1:nrow(data)) {
      if (data$slice[i] == slice_names[s]) {
        first_row <- i
        break
      }
    }
    for (i in 1:nrow(data)) {
      if (data$slice[i] == slice_names[s]) {
        last_row <- i
      }
    }
    dataset_for_avging <- data[first_row:last_row,1:ncol(X)]
    avgs <- means(dataset_for_avging)
    long_values_sliced_dataframe <- long_values_sliced_dataframe %>% append(avgs)
  }
  sliced_dataset <- matrix(long_values_sliced_dataframe, ncol = ncol(X), byrow = TRUE) %>% as.data.frame()
  #rownames(sliced_dataset) <- c(1:slices)
  return(sliced_dataset)
}

## sir_PCA

### inputs:
# sliced_data: output of slicer function. Dataframe of column-slice means.
# directions: integer, number of directions we want in our final low-dimensional Z.
# W: matrix of slice weights. For weighted SIR with spatial response, it will be generated by this point by cells_weight_matrix function.

### output: matrix of eigenvectors of (X^H)^t %*% W %*% (X^H) where X^H is matrix of scaled slice means

sir_PCA <- function(sliced_data, directions, W = diag(nrow(sliced_data))) {
  sliced_data_centered <- scale(sliced_data, center = TRUE, scale = FALSE)
  nslices <- nrow(sliced_data)
  m <- (t(as.matrix(sliced_data_centered)) %*% W %*% sliced_data_centered)/(nslices-1)
  eig_m <- eigen(m) 
  all_pc <- eig_m$vectors
  d <- min(ncol(all_pc), directions)
  return(all_pc[,1:d])
}

## multiplier

### inputs:
# data: original X data
# pc_dirs: eigenvectors of (X^H)^t %*% W %*% (X^H) as produced by sir_PCA

### output: matrix SIR directions from X, where each column of output is an SIR direction.

multiplier <- function(data, pc_dirs) {
  cov_mat <- cov(data)
  multiplied <- solve(cov_mat, pc_dirs) # note: this will give an error if p >= n
  return(multiplied)
}

## means

### input: dataframe of all rows and columns within one slice

### output: vector of means (length = number of columns in input) for mean across all rows for each column in input.

means <- function(dataset_one_slice) {
  nc <- ncol(dataset_one_slice)
  vals <- c()
  means_array <- colMeans(dataset_one_slice)
  for (i in 1:nc) {
    vals <- vals %>% append(means_array[[i]])
  }
  return(vals)
}

## spatial_allocator

### inputs:
# coords: n * 2 dataframe of spatial locations, one row per observation (cell)
  # note: the column names of coords MUST be "x" and "y" (lowercase, no quotation marks).
# slices: integer for number of slices in each direction. E.g if you use slices = 3 then you will get
  # 3 slices in each of the x and y directions, leading to 3 x 3 = 9 tiles in total. 

### output: vector of length n specifying the tile allocation of each observation.

spatial_allocator <- function(coords, slices = 3) {
  coords$id <- c(1:nrow(coords))
  coords <- coords %>% arrange(x)
  nX <- nrow(coords)
  x_allocation <- allocator(nrows = nX, slices = slices)
  coords$x_slice <- x_allocation
  
  coords <- coords %>% arrange(y)
  y_allocation <- allocator(nrows = nX, slices = slices)
  coords$y_slice <- y_allocation
  
  coords$coordinate <- paste0(coords$x_slice, ", ", coords$y_slice)
  
  coords <- arrange(coords, id)
  
  coords <- coords %>% dplyr::select(-c("x_slice", "y_slice", "id"))
  return(coords)
}

## cells_weight_matrix

### inputs:
# coords: n * 2 matrix of spatial coordinates containing one row for each observation. 
# labels: vector of length n containing tile allocation of each observation, as produced by cells_weight_matrix.
# alpha: integer, tuning parameter raising each entry of W to some power before the entries are scaled to [-1,1].
  # Motivation: further stretches away distant tiles, draws together similar ones. 
  # Default value is 1, but best to adjust. 

### output: Weight matrix of size (s^2) * (s^2) where s is the number of slices in each direction as
  # defined in the spatial_allocator function. Represents physical similarity between all pairs of tiles. 

cells_weight_matrix <- function(coords, labels, alpha = 1) {
  slices <- length(unique(labels[,1]))
  empty_df <- matrix(rep(0, slices^2), nrow = slices) %>% as.data.frame()
  
  avg_locations <- slicer(X = coords, Y = as.data.frame(labels[,1]), categorical = TRUE)
  colnames(avg_locations) <- c("x", "y")
  
  for (i in 1:slices) {
    for (j in 1:slices) {
      x_dist <- avg_locations$x[i] - avg_locations$x[j]
      y_dist <- avg_locations$y[i] - avg_locations$y[j]
      dist_pair <- sqrt(x_dist^2 + y_dist^2)
      empty_df[i,j] = dist_pair
      empty_df[j,i] = dist_pair
    }
  }
  dist_df <- 1 - empty_df / max(empty_df)
  weight_mat <- dist_df %>% as.matrix()
  powered <- weight_mat^alpha
  return(powered*2-1)
}

# User-facing functions (from sir_functions.R)

## sir_univariate

### inputs:
# X: dataframe or matrix of dimensions n * p
# Y: dataframe of size n * 1 (univariate response only), whose values are categorical or continuous (see "categorical" input)
# directions: integer for number of SIR directions you wish to return
# categorical: binary for if the response values are categorical or not
# slices: number of slices to be used for SIR computation. Not needed if response is categorical, since in that case 
  # number of slices = number of categories
# alpha: integer, tuning parameter raising each entry of W to some power before the entries are scaled to [-1,1].
  # Motivation: further stretches away distant tiles, draws together similar ones. 
  # Default value is 1, but best to adjust.
# W: weight matrix to represent similarity between the slices. Only use for categorical response. 
  # if none is provided, then (scaled) identity matrix is used. Argument alpha can still be used in that situation.

### outputs:
# [[1]]: Z: low-dimensional representation of X. Dimensions n * d, d = directions argument.
# [[2]]: B: SIR directions of size p * d (d = directions). To be used to project new data X_new of dimensions m * p into
  # low-dimensional space by performing X_new %*% B.

sir_univariate <- function(X, Y, directions = 10, categorical = FALSE, slices = 10, alpha = 1, W) {
  sliced_data <- slicer(X = X, Y = Y, slices = slices, categorical = categorical) # create sliced and averaged data
  
  # define weight matrix if not provided
  
  if (missing(W)) {
    if (categorical) {
      W = diag(table(Y[,1]))/nrow(Y)
      W = W^alpha
    } else {
      W = diag(slices)/nrow(X)
      W = W^alpha
    }
  }
  
  pc_dirs <- sir_PCA(sliced_data, directions = directions, W = W)
  
  betas <- multiplier(data = X, pc_dirs = pc_dirs)
  
  final_XB <- as.matrix(X) %*% betas
  
  return(list(final_XB, betas)) # 1 is the transformed X, 2 is the rotation (for new data)
}

## weighted_sir_package

### inputs:
# X: dataframe or matrix of dimensions n * p
# coords: n * 2 matrix of spatial coordinates containing one row for each observation. 
# slices: number of slices to be used for SIR computation. Not needed if response is categorical, since in that case 
  # number of slices = number of categories
# directions: integer for number of SIR directions you wish to return
# W: weight matrix to represent similarity between the slices, of size size (s^2) * (s^2) 
  # where s is the number of slices in each spatial direction (x, y). If not provided then it will be created
  # automatically by the cells_weight_matrix function.
# alpha: integer, tuning parameter raising each entry of W to some power before the entries are scaled to [-1,1].
  # Motivation: further stretches away distant tiles, draws together similar ones. 
  # Default value is 1.

### outputs:
# [[1]]: Z: low-dimensional representation of X. Dimensions n * d, d = directions argument.
# [[2]]: B: SIR directions of size p * d (d = directions). To be used to project new data X_new of dimensions m * p into
  # low-dimensional space by performing X_new %*% B.

weighted_sir_package <- function(X, coords, slices = 8, directions = 10, W = diag(slices)/nrow(X), alpha = 1) {
  tile_allocation <- spatial_allocator(coords = coords, slices = slices)
  if (missing(W)) {
    W <- cells_weight_matrix(coords = coords, labels = tile_allocation, alpha = alpha)
  }
  wsir_obj <- sir_univariate(X = X, 
                             Y = tile_allocation, 
                             directions = directions, 
                             categorical = TRUE, 
                             slices = slices,
                             alpha = alpha, 
                             W = W)
  return(wsir_obj)
}







